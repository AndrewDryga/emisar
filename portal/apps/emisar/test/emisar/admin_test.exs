defmodule Emisar.AdminTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Admin, Billing, Fixtures}

  describe "execute/2" do
    test "dispatches a private RPC action from ordinary name-value argv" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, result} =
               Admin.execute("emisar.admin.account.show", ["account=#{account.slug}"])

      assert result.id == account.id
      assert result.slug == account.slug
      assert result.billing.plan == "free"
    end

    test "keeps equals signs inside values and invokes support writes as system" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{disabled: true}} =
               Admin.execute("emisar.admin.account.disable", [
                 "account=#{account.slug}",
                 "reason=support=verified"
               ])

      assert {:error, :not_found} = Emisar.Accounts.fetch_account_by_id(account.id)
    end

    test "rejects malformed, duplicate, excessive, and non-admin arguments" do
      assert {:error, :invalid_admin_arguments} =
               Admin.execute("emisar.admin.account.show", ["account"])

      assert {:error, :invalid_admin_arguments} =
               Admin.execute("emisar.admin.account.show", ["account=one", "account=two"])

      assert {:error, :invalid_admin_request} =
               Admin.execute("emisar.admin.account.show", ["a=1", "b=2", "c=3", "d=4"])

      assert {:error, :invalid_admin_request} = Admin.execute("linux.uptime", [])
    end

    test "complimentary plans use the existing subscription posture" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{plan: "team", source: "complimentary"}} =
               Admin.execute("emisar.admin.plan.grant", [
                 "account=#{account.slug}",
                 "plan=team",
                 "reason=design partner"
               ])

      assert Billing.account_plan(account) == "team"

      assert {:ok, %{subscriptions: subscriptions}} =
               Admin.execute("emisar.admin.analytics.revenue", [])

      assert %{plan: "team", status: "complimentary", accounts: 1} in subscriptions
    end
  end
end
