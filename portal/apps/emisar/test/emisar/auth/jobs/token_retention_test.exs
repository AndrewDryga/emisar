defmodule Emisar.Auth.Jobs.TokenRetentionTest do
  use Emisar.DataCase, async: true
  alias Emisar.Auth.Jobs.TokenRetention
  alias Emisar.Auth.UserToken
  alias Emisar.Fixtures
  alias Emisar.Repo

  setup do
    %{user: Fixtures.Users.create_user()}
  end

  test "runs daily because the longest window is counted in days" do
    assert %{
             id: TokenRetention,
             start: {_executor, :start_link, [{TokenRetention, interval, _config}]}
           } = TokenRetention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "deletes a token past its own context's window and keeps one inside it", %{user: user} do
    now = DateTime.utc_now()
    expired = Fixtures.Auth.create_aged_token!(user, "magic_link", DateTime.add(now, -3600))
    live = Fixtures.Auth.create_aged_token!(user, "magic_link", DateTime.add(now, -60))

    assert TokenRetention.execute([]) == :ok

    refute Repo.reload(expired)
    assert Repo.reload(live)
  end

  test "keeps a live magic-link factor waiting on an MFA challenge", %{user: user} do
    # The factor's own 10-minute window runs from `verified_at`, which is up to
    # a whole pending window later than the `inserted_at` this sweep compares.
    verified = Fixtures.Auth.create_aged_token!(user, "magic_link_verified", minutes_ago(20))

    assert TokenRetention.execute([]) == :ok

    assert Repo.reload(verified)
  end

  test "keeps a pending MFA-enrollment code its mailer has not finished", %{user: user} do
    pending = Fixtures.Auth.create_aged_token!(user, "mfa_enrollment_pending", minutes_ago(5))

    assert TokenRetention.execute([]) == :ok

    assert Repo.reload(pending)
  end

  test "sweeps every context once it is past its window", %{user: user} do
    contexts =
      ~w(session confirm magic_link magic_link_verified email_change
         mfa_enrollment_pending mfa_enrollment oidc_identity_step_up)

    for context <- contexts do
      Fixtures.Auth.create_aged_token!(
        user,
        context,
        DateTime.add(DateTime.utc_now(), -365, :day)
      )
    end

    assert TokenRetention.execute([]) == :ok

    refute Repo.one(UserToken)
  end

  test "sweeps a row whose context the code no longer recognizes", %{user: user} do
    stale = Fixtures.Auth.create_aged_token!(user, "retired_flow", DateTime.utc_now())

    assert TokenRetention.execute([]) == :ok

    refute Repo.reload(stale)
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
end
