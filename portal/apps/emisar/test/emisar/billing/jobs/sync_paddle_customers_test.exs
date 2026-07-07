defmodule Emisar.Billing.Jobs.SyncPaddleCustomersTest do
  use Emisar.DataCase, async: true
  alias Emisar.Billing.Jobs.SyncPaddleCustomers
  alias Emisar.Fixtures
  alias Emisar.Repo

  describe "execute/1" do
    test "syncs stale accounts from a scheduled page" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()

      assert :ok = SyncPaddleCustomers.execute([])

      assert Repo.reload!(account).paddle_customer_id
    end

    test "does not fail an account with no confirmed owner email" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user(confirmed?: false)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      assert :ok = SyncPaddleCustomers.execute([])
      refute Repo.reload!(account).paddle_customer_id
    end
  end
end
