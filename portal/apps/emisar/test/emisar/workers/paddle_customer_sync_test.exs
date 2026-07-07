defmodule Emisar.Workers.PaddleCustomerSyncTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Fixtures, Repo}
  alias Emisar.Workers.PaddleCustomerSync

  describe "perform/1" do
    test "syncs one account from string-key Oban args" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()

      assert :ok = PaddleCustomerSync.perform(%Oban.Job{args: %{"account_id" => account.id}})

      assert Repo.reload!(account).paddle_customer_id
    end

    test "runs a scheduled page with string-key args" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()

      assert :ok = PaddleCustomerSync.perform(%Oban.Job{args: %{"limit" => 1}})

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

      assert :ok = PaddleCustomerSync.perform(%Oban.Job{args: %{"account_id" => account.id}})
      refute Repo.reload!(account).paddle_customer_id
    end
  end
end
