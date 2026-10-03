defmodule Emisar.WorkspaceProfileAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Fixtures, Repo, SSO}
  alias Emisar.SSO.SCIMUserUpdate

  describe "fetch_own_member_profile/1" do
    test "returns only this account's exact member and refuses foreign or missing actors" do
      {person, account, subject} = Fixtures.Subjects.owner_subject()

      elsewhere =
        Fixtures.Memberships.create_membership(email: person.email, display_name: "Elsewhere")

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
      {_provider, _identity, member} = provisioned()
      subject = Fixtures.Subjects.subject_for(member)
      assert {:ok, %{editable?: false}} = Accounts.fetch_own_member_profile(subject)
    end
  end

  describe "change_member_profile/2" do
    test "validates the display name without accepting authority or contact fields" do
      member = %Accounts.Membership{
        display_name: "Original",
        email: "work@example.test",
        role: :viewer
      }

      changeset =
        Accounts.change_member_profile(member, %{
          display_name: "New",
          email: "wrong@example.test",
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
      elsewhere = Fixtures.Memberships.create_membership(email: person.email)

      assert {:ok, updated} =
               Accounts.update_own_member_profile(
                 %{display_name: "Work Name", email: "stolen@example.test", role: :viewer},
                 subject
               )

      assert updated.id == subject.membership_id
      assert updated.display_name == "Work Name"
      assert updated.email == person.email
      assert updated.role == :owner
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
      {_provider, _identity, member} = provisioned()
      subject = Fixtures.Subjects.subject_for(member)

      assert {:error, :directory_managed_profile} =
               Accounts.update_own_member_profile(%{display_name: "Spoof"}, subject)

      assert Repo.reload!(member).display_name == "Directory Name"

      {person, _account, ordinary} = Fixtures.Subjects.owner_subject()
      elsewhere = Fixtures.Memberships.create_membership(email: person.email)

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

      member = Repo.reload!(person)
      Fixtures.Memberships.mark_membership_as_deleted(member)

      assert {:error, :unauthorized} =
               Accounts.update_own_member_profile(%{display_name: "Spoof"}, ordinary)

      assert Repo.reload!(elsewhere) == elsewhere
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
    subject = Fixtures.Subjects.subject_for(admin)
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
    Fixtures.Memberships.force_role(admin, "viewer")

    assert {:error, :unauthorized} =
             Accounts.update_member_profile_as_admin(target, %{display_name: "Spoof"}, subject)

    assert Repo.reload!(target) == target
  end

  test "workspace approval mail uses the Member's own contact and name" do
    member =
      Fixtures.Memberships.create_membership(
        display_name: "Work Name",
        email: "work@example.test"
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
    assert email.text_body =~ "Work Name"

    assert {:error, :no_contact_email} =
             Emisar.Mailers.UserNotifier.deliver_approval_decision(
               %{member | email: nil},
               request
             )

    refute_received {:email, _}
  end

  test "a workspace administrator changes only this member's local name" do
    {_owner, account, subject} = Fixtures.Subjects.owner_subject()

    member =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        display_name: "Personal Name"
      )

    elsewhere = Fixtures.Memberships.create_membership(email: member.email)

    assert {:ok, _} =
             Accounts.update_member_profile_as_admin(
               member,
               %{"display_name" => "Workspace Name"},
               subject
             )

    assert Repo.reload!(member).display_name == "Workspace Name"
    assert Repo.reload!(elsewhere) == elsewhere
  end

  test "a directory partial rename merges into the Member's directory-owned name" do
    {provider, identity, member} = provisioned()

    assert {:ok, _} =
             SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{
               name: {:merge, %{family: "Changed"}}
             })

    assert Repo.reload!(member).display_name == "Directory Changed"
  end

  defp provisioned do
    {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    {:ok, provider, _token} = SSO.enable_scim(provider, subject)

    {:ok, %{identity: identity, membership: member}} =
      SSO.scim_provision_user(provider, %{
        external_id: "directory-person",
        email: "directory@example.test",
        full_name: "Directory Name"
      })

    {provider, identity, member}
  end
end
