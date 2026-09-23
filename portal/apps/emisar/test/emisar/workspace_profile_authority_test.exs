defmodule Emisar.WorkspaceProfileAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Fixtures, Repo, SSO, Users}
  alias Emisar.SSO.SCIMUserUpdate

  describe "fetch_own_member_profile/1" do
    test "returns only this account's exact member and refuses foreign or missing actors" do
      {person, account, subject} = Fixtures.Subjects.owner_subject()

      elsewhere =
        Fixtures.Memberships.create_membership(user_id: person.id, display_name: "Elsewhere")

      assert {:ok, %{membership: member, editable?: true}} =
               Accounts.fetch_own_member_profile(subject)

      assert member.id == subject.membership_id
      assert member.account_id == account.id

      assert {:error, :unauthorized} =
               Accounts.fetch_own_member_profile(%{subject | membership_id: elsewhere.id})

      assert {:error, :unauthorized} = Accounts.fetch_own_member_profile(%{subject | actor: nil})

      assert {:error, :unauthorized} =
               Accounts.fetch_own_member_profile(%{subject | permissions: MapSet.new()})
    end

    test "marks a directory-owned name read-only" do
      {_provider, _person, _identity, member} = provisioned()
      subject = Fixtures.Subjects.membership_subject(member)
      assert {:ok, %{editable?: false}} = Accounts.fetch_own_member_profile(subject)
    end
  end

  describe "change_member_profile/2" do
    test "validates the display name without accepting authority or contact fields" do
      member = %Accounts.Membership{
        display_name: "Original",
        contact_email: "work@example.test",
        role: :viewer
      }

      changeset =
        Accounts.change_member_profile(member, %{
          display_name: "New",
          contact_email: "wrong@example.test",
          role: :owner
        })

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset) == %{member | display_name: "New"}

      refute Accounts.change_member_profile(member, %{display_name: String.duplicate("a", 256)}).valid?
    end
  end

  describe "update_own_member_profile/2" do
    test "changes and audits only the local name, including clearing it" do
      {person, account, subject} = Fixtures.Subjects.owner_subject()
      elsewhere = Fixtures.Memberships.create_membership(user_id: person.id)

      assert {:ok, updated} =
               Accounts.update_own_member_profile(
                 %{
                   display_name: "Work Name",
                   contact_email: "stolen@example.test",
                   user_id: Ecto.UUID.generate()
                 },
                 subject
               )

      assert updated.id == subject.membership_id
      assert updated.display_name == "Work Name"
      assert updated.contact_email == person.email
      assert Repo.reload!(person) == person
      assert Repo.reload!(elsewhere) == elsewhere

      event =
        Repo.one!(
          from e in Emisar.Audit.Event,
            where: e.account_id == ^account.id and e.event_type == "membership.profile_updated"
        )

      assert event.payload == %{"display_name" => "Work Name"}
      assert event.target_label == "Work Name"

      assert {:ok, cleared} = Accounts.update_own_member_profile(%{display_name: ""}, subject)
      assert Accounts.member_display_name(cleared) == person.email
    end

    test "directory management, removed memberships, API credentials and crossed member IDs deny writes" do
      {_provider, _person, _identity, member} = provisioned()
      subject = Fixtures.Subjects.membership_subject(member)

      assert {:error, :directory_managed_profile} =
               Accounts.update_own_member_profile(%{display_name: "Spoof"}, subject)

      assert Repo.reload!(member).display_name == "Directory Name"

      {person, _account, ordinary} = Fixtures.Subjects.owner_subject()
      elsewhere = Fixtures.Memberships.create_membership(user_id: person.id)

      assert {:error, :unauthorized} =
               Accounts.update_own_member_profile(%{display_name: "Spoof"}, %{
                 ordinary
                 | membership_id: elsewhere.id
               })

      assert {:error, :unauthorized} =
               Accounts.update_own_member_profile(%{display_name: "Spoof"}, %{
                 ordinary
                 | actor: %Emisar.ApiKeys.ApiKey{}
               })

      member = Fixtures.Memberships.fetch_membership(ordinary.account.id, person.id)
      Fixtures.Memberships.mark_membership_as_deleted(member)

      assert {:error, :unauthorized} =
               Accounts.update_own_member_profile(%{display_name: "Spoof"}, ordinary)

      assert Repo.reload!(elsewhere) == elsewhere
    end
  end

  describe "peek_membership_profile/2" do
    test "uses only the requested account, preserving removed-member display facts" do
      member = Fixtures.Memberships.create_membership(display_name: "Work Name")
      Fixtures.Memberships.mark_membership_as_deleted(member)

      assert Accounts.peek_membership_profile(member.account_id, member.user_id).display_name ==
               "Work Name"

      assert Accounts.peek_membership_profile(Ecto.UUID.generate(), member.user_id) == nil
    end
  end

  describe "list_membership_profiles_by_id/2" do
    test "deduplicates exact histories and excludes unresolved or foreign bindings" do
      member = Fixtures.Memberships.create_membership()
      Fixtures.Memberships.mark_membership_as_deleted(member)
      outsider = Fixtures.Memberships.create_membership()

      assert [found] =
               Accounts.list_membership_profiles_by_id(member.account_id, [
                 member.id,
                 member.id,
                 outsider.id,
                 nil
               ])

      assert found.id == member.id
      assert found.deleted_at
      assert Accounts.list_membership_profiles_by_id(member.account_id, []) == []
    end
  end

  test "a stale administrator cannot rename after losing their role" do
    {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
    admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    subject = Fixtures.Subjects.membership_subject(admin)
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
    Fixtures.Memberships.force_role(admin, "viewer")

    assert {:error, :unauthorized} =
             Accounts.update_member_profile_as_admin(target, %{display_name: "Spoof"}, subject)

    assert Repo.reload!(target) == target
  end

  test "workspace approval mail uses the local contact and name, never the personal profile" do
    person = Fixtures.Users.create_user(email: "private@example.test", full_name: "Private Name")

    member =
      Fixtures.Memberships.create_membership(
        user_id: person.id,
        display_name: "Work Name",
        contact_email: "work@example.test"
      )

    request = %{
      id: Ecto.UUID.generate(),
      account: Repo.get!(Accounts.Account, member.account_id),
      status: :approved,
      context: %{"action_id" => "linux.uptime"}
    }

    assert {:ok, _} = Emisar.Mailers.UserNotifier.deliver_approval_decision(member, request)
    assert_received {:email, email}
    assert email.to == [{"", "work@example.test"}]
    refute email.text_body =~ "Private Name"
    refute email.text_body =~ "private@example.test"

    assert {:error, :no_contact_email} =
             Emisar.Mailers.UserNotifier.deliver_approval_decision(
               %{member | contact_email: nil},
               request
             )

    refute_received {:email, _}
  end

  test "anonymous invitation acceptance retains the explicitly supplied workspace name" do
    {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

    {:ok, invitation} =
      Accounts.invite_user_to_account(%{email: "new@example.test", role: "viewer"}, subject)

    assert invitation.membership.display_name == nil

    assert {:ok, %{membership: accepted}} =
             Accounts.accept_invitation(invitation.membership, invitation.invitation_token, %{
               display_name: "New Teammate"
             })

    assert accepted.display_name == "New Teammate"
    assert accepted.contact_email == "new@example.test"
  end

  test "a workspace administrator changes only this member's local name" do
    {_owner, account, subject} = Fixtures.Subjects.owner_subject()
    person = Fixtures.Users.create_user(full_name: "Personal Name")
    member = Fixtures.Memberships.create_membership(account_id: account.id, user_id: person.id)
    elsewhere = Fixtures.Memberships.create_membership(user_id: person.id)

    assert {:ok, _} =
             Accounts.update_member_profile_as_admin(
               member,
               %{"display_name" => "Workspace Name"},
               subject
             )

    assert Repo.reload!(person).full_name == "Personal Name"
    assert Repo.reload!(member).display_name == "Workspace Name"
    assert Repo.reload!(elsewhere) == elsewhere
  end

  test "personal changes retain audit facts without sharing private values" do
    {person, account, subject} = Fixtures.Subjects.owner_subject()
    {_other_owner, other_account, other_reader} = Fixtures.Subjects.owner_subject()

    member = Fixtures.Memberships.fetch_membership(account.id, person.id)
    member |> Ecto.Changeset.change(display_name: "Work A") |> Repo.update!()

    other_member =
      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: person.id,
        display_name: "Work B"
      )

    context = %Emisar.RequestContext{
      ip_address: "203.0.113.17",
      user_agent: "Private Browser",
      request_id: "personal-profile-request"
    }

    personal = %{subject | auth_method: :magic_link, context: context}
    assert {:ok, _} = Users.update_user_profile(%{full_name: "Private Updated Name"}, personal)

    assert {:ok, _} =
             Ecto.Multi.new()
             |> Users.put_email_change(
               Repo.reload!(person),
               "private-updated@example.test",
               context
             )
             |> Repo.commit_multi()

    opts = [filter: [event_type: ["user.profile_updated", "user.email_changed"]]]

    for {reader, label, member_id} <- [
          {subject, "Work A", member.id},
          {other_reader, "Work B", other_member.id}
        ] do
      assert {:ok, events, _} = Emisar.Audit.list_events(reader, opts)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.actor_id == member_id and &1.target_id == member_id))
      assert Enum.all?(events, &(&1.target_label == label and &1.payload == %{}))
      assert Enum.all?(events, &is_nil(&1.actor_label))
      assert Enum.all?(events, &(&1.ip_address == nil and &1.user_agent == nil))
      assert Enum.all?(events, &(&1.request_id == context.request_id))
    end
  end

  test "directory reads and filters keep local contact and name after a personal profile change" do
    {provider, person, identity, _member} = provisioned()

    {:ok, _} =
      person
      |> Ecto.Changeset.change(email: "private@example.test", full_name: "Private Name")
      |> Repo.update()

    assert {:ok, resource} = SSO.scim_fetch_user(provider, identity.id)
    assert resource.user_name == "directory@example.test"
    assert resource.display_name == "Directory Name"

    assert {:ok, [%{id: id}], 1} =
             SSO.scim_list_users(provider, scim_filter: {:user_name, "directory@example.test"})

    assert id == identity.id

    assert {:ok, [], 0} =
             SSO.scim_list_users(provider, scim_filter: {:user_name, "private@example.test"})
  end

  test "directory partial rename merges local facts and never rewrites even a sole personal user" do
    {provider, person, identity, member} = provisioned()

    {:ok, _} =
      person |> Users.User.Changeset.profile(%{full_name: "Private Surname"}) |> Repo.update()

    assert {:ok, _} =
             SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{
               name: {:merge, %{family: "Changed"}}
             })

    assert Repo.reload!(person).full_name == "Private Surname"
    assert Repo.reload!(member).display_name == "Directory Changed"
  end

  defp provisioned do
    {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    {:ok, provider, _token} = SSO.enable_scim(provider, subject)

    {:ok, %{user: person, identity: identity, membership: member}} =
      SSO.scim_provision_user(provider, %{
        external_id: "directory-person",
        email: "directory@example.test",
        full_name: "Directory Name"
      })

    {provider, person, identity, member}
  end
end
