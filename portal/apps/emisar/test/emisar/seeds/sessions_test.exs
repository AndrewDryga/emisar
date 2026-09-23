defmodule Emisar.Seeds.SessionsTest do
  use Emisar.DataCase, async: false
  alias Emisar.{Auth, Fixtures, Repo}

  setup_all do
    helpers = Emisar.Seeds.Helpers
    staff = Emisar.Seeds.StaffAccount
    Code.require_file(Application.app_dir(:emisar, "priv/repo/seeds/helpers.exs"))
    Code.require_file(Application.app_dir(:emisar, "priv/repo/seeds/staff_account.exs"))
    %{helpers: helpers, staff: staff}
  end

  test "failure cleans only owned sessions and their grants", %{helpers: helpers} do
    {user, account, existing} = Fixtures.Subjects.owner_subject()
    {:ok, retained} = Auth.fetch_current_session(existing)

    assert_raise RuntimeError, "failed section", fn ->
      helpers.with_temporary_sessions(fn ->
        subject = helpers.subject_for(account, user)
        assert :ok = Auth.ensure_personal_session(subject)
        refute subject.session_token_id == retained.id
        assert Repo.aggregate(Auth.MemberGrant, :count) == 2
        raise "failed section"
      end)
    end

    assert Repo.all(Auth.UserToken.Query.by_context("session")) |> Enum.map(& &1.id) == [
             retained.id
           ]

    assert Repo.aggregate(Auth.MemberGrant, :count) == 1
    assert Repo.aggregate(Auth.MemberGrantRoute, :count) == 1
    assert Auth.ensure_personal_session(existing) == :ok
  end

  test "persona MFA reset still proves the actual factor and leaves no seed credential", %{
    helpers: helpers
  } do
    user = Fixtures.Users.create_user()
    secret = Auth.generate_mfa_secret()

    user =
      Fixtures.Users.set_mfa_state(user, mfa_secret: secret, mfa_enabled_at: DateTime.utc_now())

    helpers.with_temporary_sessions(fn ->
      updated = helpers.clear_seeded_mfa(user)
      assert is_nil(updated.mfa_enabled_at)
      assert is_nil(updated.mfa_secret)
    end)

    refute Repo.exists?(Auth.UserToken.Query.by_context("session"))
    assert is_nil(Repo.reload!(user).mfa_enabled_at)
  end

  test "reseed preserves the staff persona's MFA enrollment", %{helpers: helpers, staff: staff} do
    user = Fixtures.Users.create_user(email: "admin@emisar.dev")
    secret = Auth.generate_mfa_secret()

    user =
      Fixtures.Users.set_mfa_state(user, mfa_secret: secret, mfa_enabled_at: DateTime.utc_now())

    ExUnit.CaptureIO.capture_io(fn ->
      helpers.with_temporary_sessions(fn -> staff.run() end)
    end)

    current = Repo.reload!(user)
    assert current.mfa_enabled_at == user.mfa_enabled_at
    assert current.mfa_secret == secret
    assert current.is_admin
    refute Repo.exists?(Auth.UserToken.Query.by_context("session"))
  end
end
