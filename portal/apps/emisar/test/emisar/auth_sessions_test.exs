defmodule Emisar.AuthSessionsTest do
  @moduledoc """
  Behavioural coverage for the user-facing session management surface:
  list, revoke one, revoke-others-keep-current. Not concerned with how
  session tokens are minted (that lives in AuthTest) — only what the
  Profile page calls.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures
  alias Emisar.Auth

  describe "list_sessions_for_user/2" do
    test "returns rows newest-first" do
      user = user_fixture()
      _ = Auth.create_session_token!(user)
      _ = Auth.create_session_token!(user)
      _ = Auth.create_session_token!(user)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(user)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "only returns this user's tokens" do
      mine = user_fixture()
      theirs = user_fixture()
      _ = Auth.create_session_token!(mine)
      _ = Auth.create_session_token!(theirs)

      assert {:ok, [_], _meta} = Auth.list_sessions_for_user(mine)
    end

    test "only includes session-context tokens (not magic-link or reset)" do
      user = user_fixture()
      _ = Auth.create_session_token!(user)
      _ = Auth.issue_magic_link_token!(user)
      _ = Auth.issue_password_reset_token!(user)

      assert {:ok, [token], _meta} = Auth.list_sessions_for_user(user)
      assert token.context == "session"
    end
  end

  describe "revoke_session/2" do
    test ":ok and the row goes away" do
      user = user_fixture()
      _ = Auth.create_session_token!(user)
      assert {:ok, [s], _} = Auth.list_sessions_for_user(user)

      assert :ok = Auth.revoke_session(user, s.id)
      assert {:ok, [], _} = Auth.list_sessions_for_user(user)
    end

    test "refuses to revoke another user's session via id" do
      mine = user_fixture()
      theirs = user_fixture()
      _ = Auth.create_session_token!(theirs)
      assert {:ok, [their_session], _} = Auth.list_sessions_for_user(theirs)

      assert {:error, :not_found} = Auth.revoke_session(mine, their_session.id)
      assert {:ok, [_], _} = Auth.list_sessions_for_user(theirs)
    end

    test "rejects a malformed id without hitting the DB" do
      user = user_fixture()
      assert {:error, :not_found} = Auth.revoke_session(user, "not-a-uuid")
    end
  end

  describe "revoke_other_sessions!/2" do
    test "keeps the caller's current session" do
      user = user_fixture()
      keep = Auth.create_session_token!(user)
      _ = Auth.create_session_token!(user)
      _ = Auth.create_session_token!(user)

      assert Auth.revoke_other_sessions!(user, keep) == 2
      assert {:ok, [survivor], _} = Auth.list_sessions_for_user(user)
      assert survivor.token == :crypto.hash(:sha256, keep)
    end

    test "with nil, kills every session including the caller's" do
      user = user_fixture()
      _ = Auth.create_session_token!(user)
      _ = Auth.create_session_token!(user)

      assert Auth.revoke_other_sessions!(user, nil) == 2
      assert {:ok, [], _} = Auth.list_sessions_for_user(user)
    end
  end
end
