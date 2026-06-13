defmodule Emisar.Audit.MultiTest do
  @moduledoc """
  `Audit.Multi.log_for_user/5` — the transactional audit primitive for
  user-scoped events (sign-in, session revocation, password reset). It
  derives `account_id` from the user's membership and commits the audit
  row atomically with the parent transaction. These pin its branches
  directly rather than only through the Auth flows that lean on it.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Ecto.Multi
  alias Emisar.Audit

  defp user_with_membership do
    user = user_fixture()
    account = account_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    {user, account}
  end

  describe "log_for_user/5" do
    test "inserts an audit row, deriving account_id from the user's membership" do
      {user, account} = user_with_membership()

      assert {:ok, %{audit: event}} =
               Multi.new()
               |> Audit.Multi.log_for_user(:audit, user, "user.test_event")
               |> Repo.commit_multi()

      assert event.event_type == "user.test_event"
      assert event.actor_id == user.id
      assert event.account_id == account.id
    end

    test "no-ops (no row) when the user has no active membership" do
      user = user_fixture()

      assert {:ok, %{audit: nil}} =
               Multi.new()
               |> Audit.Multi.log_for_user(:audit, user, "user.test_event")
               |> Repo.commit_multi()
    end

    test "a :user_fn resolving nil skips the step" do
      {user, _account} = user_with_membership()

      assert {:ok, %{audit: nil}} =
               Multi.new()
               |> Audit.Multi.log_for_user(:audit, user, "user.test_event",
                 user_fn: fn _changes -> nil end
               )
               |> Repo.commit_multi()
    end

    test "a :payload_fn computes the payload from the multi's changes" do
      {user, _account} = user_with_membership()

      assert {:ok, %{audit: event}} =
               Multi.new()
               |> Multi.run(:revoked_count, fn _repo, _changes -> {:ok, 2} end)
               |> Audit.Multi.log_for_user(:audit, user, "user.other_sessions_revoked",
                 payload_fn: fn %{revoked_count: n} -> %{"revoked" => n} end
               )
               |> Repo.commit_multi()

      assert event.payload["revoked"] == 2
    end

    test "raises when given neither a user nor a :user_fn to resolve one" do
      assert_raise ArgumentError, fn ->
        Audit.Multi.log_for_user(Multi.new(), :audit, nil, "user.test_event")
      end
    end
  end
end
