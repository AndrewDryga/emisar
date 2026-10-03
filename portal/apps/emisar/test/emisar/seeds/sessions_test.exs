defmodule Emisar.Seeds.SessionsTest do
  use Emisar.DataCase, async: false
  alias Emisar.{Admin, Auth, Fixtures, Repo}

  setup_all do
    helpers = Emisar.Seeds.Helpers
    staff = Emisar.Seeds.StaffAccount
    Code.require_file(Application.app_dir(:emisar, "priv/repo/seeds/helpers.exs"))
    Code.require_file(Application.app_dir(:emisar, "priv/repo/seeds/staff_account.exs"))
    %{helpers: helpers, staff: staff}
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

  test "reseed keeps the staff login and its authenticator key", %{staff: staff} do
    {:ok, created, secret} = Admin.create_staff("admin@emisar.dev")

    output = ExUnit.CaptureIO.capture_io(fn -> staff.run() end)

    assert output =~ "kept"
    assert [current] = Admin.list_staff()
    assert current.id == created.id
    assert current.mfa_secret == secret
  end

  test "a first seed creates the staff login and prints its key once", %{staff: staff} do
    output = ExUnit.CaptureIO.capture_io(fn -> staff.run() end)

    assert [created] = Admin.list_staff()
    assert created.email == "admin@emisar.dev"
    assert output =~ Base.encode32(created.mfa_secret, padding: false)
  end
end
