defmodule Emisar.AdminTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Admin, Billing, Fixtures}

  describe "job_modules/0" do
    # DataCase shares the sandbox for every async: false test, so a job left
    # enabled in the test env runs update_all/delete_all INSIDE whichever test
    # is executing when its interval elapses. Three jobs had leaked that way and
    # only misfired on wall-clock timing, which reads as a flake.
    test "every recurrent job is disabled in the test environment" do
      enabled = Enum.filter(Admin.job_modules(), &job_enabled?/1)

      assert enabled == [],
             "these jobs tick inside the test sandbox; disable them in config/test.exs: #{inspect(enabled)}"
    end
  end

  defp job_enabled?(module), do: Emisar.Config.get_env(:emisar, module, [])[:enabled] != false

  describe "execute/2" do
    # user.erase is irreversible — the user AND every account they own — and its
    # only guard is a `when user_id == confirmation` function head. Nothing
    # covered it in either direction. This module has already shipped this exact
    # class: the note at the top of this file records that all four break-glass
    # verbs crashed on a nil dereference with none of them covered. A clause
    # reordering or head rewrite that shadows the guard turns a typo'd argv —
    # runner-supplied — into an erasure.
    test "erases a user only when the confirmation matches the user id" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()

      assert {:error, {:unsupported_admin_action, "emisar.admin.user.erase"}} =
               Admin.execute("emisar.admin.user.erase", [
                 "user_id=#{user.id}",
                 "confirmation=not-the-user-id",
                 "reason=typo in the confirmation"
               ])

      assert {:ok, %{id: _}} = Emisar.Users.fetch_user_by_id(user.id)

      assert {:ok, %{erased_user_id: erased}} =
               Admin.execute("emisar.admin.user.erase", [
                 "user_id=#{user.id}",
                 "confirmation=#{user.id}",
                 "reason=verified erasure request"
               ])

      assert erased == user.id
      assert Emisar.Users.fetch_user_by_id(user.id) == {:error, :not_found}
    end

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

    # These four run under `support_subject/1`, which has no actor. Every one of
    # them crashed on a nil dereference in the membership guard — the break-glass
    # verbs an operator reaches for during an incident, none of them covered.
    test "runs the member break-glass verbs under an actorless support subject" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      args = ["account=#{account.slug}", "member=#{user.email}"]

      assert {:ok, suspended} = Admin.execute("emisar.admin.member.suspend", args)
      assert suspended.id == membership.id

      # The written row carries no :user preload, so the email has to come from
      # the membership the dispatcher already fetched.
      assert suspended.email == user.email

      assert {:ok, _} = Admin.execute("emisar.admin.member.reinstate", args)
      assert {:ok, _} = Admin.execute("emisar.admin.sessions.revoke", args)
      assert {:ok, _} = Admin.execute("emisar.admin.mfa.reset", args)
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
