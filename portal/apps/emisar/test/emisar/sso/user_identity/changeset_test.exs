defmodule Emisar.SSO.UserIdentity.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.SSO.UserIdentity

  @attrs %{provider_identifier: "sub-1", created_by: :admin, provisioned_via: :manual}

  describe "create/4" do
    test "binds an identity to a person's seat" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      changeset = UserIdentity.Changeset.create(account.id, provider.id, membership, @attrs)

      assert changeset.valid?
    end

    test "never binds an identity to a service account" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)

      changeset = UserIdentity.Changeset.create(account.id, provider.id, service_account, @attrs)

      assert "is a service account, which never signs in" in errors_on(changeset).membership_id
    end
  end

  describe "bind_membership/2" do
    test "never rebinds an identity onto a service account" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)

      identity =
        account.id
        |> UserIdentity.Changeset.create(provider.id, membership, @attrs)
        |> Repo.insert!()

      changeset = UserIdentity.Changeset.bind_membership(identity, service_account)

      assert "is a service account, which never signs in" in errors_on(changeset).membership_id
    end
  end
end
