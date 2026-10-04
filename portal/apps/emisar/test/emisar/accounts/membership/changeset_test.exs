defmodule Emisar.Accounts.Membership.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.{Membership, RunnerAccess}
  alias Emisar.Fixtures

  describe "create_service_account/3" do
    test "is a named operator seat with the given reach and no address" do
      account = Fixtures.Accounts.create_account()
      {:ok, access} = RunnerAccess.restricted(["web"], [])

      changeset =
        Membership.Changeset.create_service_account(account.id, %{display_name: "Ryker"}, access)

      assert changeset.valid?
      assert changeset.data.kind == :service_account
      assert changeset.data.role == :operator

      assert changeset.changes == %{
               account_id: account.id,
               display_name: "Ryker",
               runner_access_mode: :restricted
             }
    end

    test "requires a name" do
      account = Fixtures.Accounts.create_account()

      for blank <- [nil, "", "   "] do
        changeset =
          Membership.Changeset.create_service_account(
            account.id,
            %{display_name: blank},
            RunnerAccess.all()
          )

        assert "can't be blank" in errors_on(changeset).display_name
      end
    end

    test "bounds the name at 255 characters" do
      account = Fixtures.Accounts.create_account()
      name = String.duplicate("a", 256)

      changeset =
        Membership.Changeset.create_service_account(
          account.id,
          %{display_name: name},
          RunnerAccess.all()
        )

      assert "should be at most 255 character(s)" in errors_on(changeset).display_name
    end

    test "the database refuses a service account with an address" do
      account = Fixtures.Accounts.create_account()

      changeset =
        account.id
        |> Membership.Changeset.create_service_account(
          %{display_name: "Ryker"},
          RunnerAccess.all()
        )
        |> Ecto.Changeset.put_change(:email, "ryker@example.test")

      assert {:error, changeset} = Repo.insert(changeset)
      assert "is invalid" in errors_on(changeset).kind
    end
  end

  describe "profile/2" do
    test "a service account keeps a name" do
      service_account = Fixtures.Memberships.create_service_account()

      changeset = Membership.Changeset.profile(service_account, %{display_name: ""})

      assert "can't be blank" in errors_on(changeset).display_name
    end

    test "a person may clear their name and fall back to their address" do
      membership = Fixtures.Memberships.create_membership()

      changeset = Membership.Changeset.profile(membership, %{display_name: ""})

      assert changeset.valid?
    end
  end
end
