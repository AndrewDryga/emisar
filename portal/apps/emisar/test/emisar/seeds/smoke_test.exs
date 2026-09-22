defmodule Emisar.Seeds.SmokeTest do
  use Emisar.DataCase, async: false
  alias Emisar.{Accounts, Users}

  test "the development seed builds usable demo, partial and empty accounts" do
    # Seeds select synchronous notifications; test.exs already uses that value,
    # so evaluating the real entry point leaves global configuration unchanged.
    assert Application.fetch_env!(:emisar, :notify_approvers_async?) == false

    ExUnit.CaptureIO.capture_io(fn ->
      Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
    end)

    for {email, slug} <- [
          {"demo@emisar.dev", "demo"},
          {"demo@emisar.dev", "both-connected"},
          {"owner@acme.test", "acme"},
          {"owner@globex.test", "globex"},
          {"owner@blank.test", "blank"}
        ] do
      assert {:ok, user} = Users.fetch_user_by_email(email)
      assert {:ok, membership} = Accounts.fetch_membership_by_account_id_or_slug(user, slug, nil)
      assert membership.account.slug == slug
    end
  end
end
