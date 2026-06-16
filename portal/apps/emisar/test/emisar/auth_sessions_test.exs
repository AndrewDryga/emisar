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
    test "returns the caller's rows newest-first" do
      {user, _account, subject} = owner_subject_fixture()
      _ = Auth.create_session_token!(user, :password, false)
      _ = Auth.create_session_token!(user, :password, false)
      _ = Auth.create_session_token!(user, :password, false)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "only returns the subject's own tokens" do
      {mine, _account, my_subject} = owner_subject_fixture()
      theirs = user_fixture()
      _ = Auth.create_session_token!(mine, :password, false)
      _ = Auth.create_session_token!(theirs, :password, false)

      assert {:ok, [_], _meta} = Auth.list_sessions_for_user(my_subject)
    end

    test "only includes session-context tokens (not magic-link or reset)" do
      {user, _account, subject} = owner_subject_fixture()
      _ = Auth.create_session_token!(user, :password, false)
      _ = Auth.issue_magic_link_token!(user)
      _ = Auth.issue_password_reset_token!(user)

      assert {:ok, [token], _meta} = Auth.list_sessions_for_user(subject)
      assert token.context == "session"
    end
  end

  describe "revoke_session/2" do
    test ":ok and the row goes away" do
      {user, _account, subject} = owner_subject_fixture()
      _ = Auth.create_session_token!(user, :password, false)
      assert {:ok, [session], _} = Auth.list_sessions_for_user(subject)

      assert :ok = Auth.revoke_session(session.id, subject)
      assert {:ok, [], _} = Auth.list_sessions_for_user(subject)
    end

    test "refuses to revoke another user's session via id" do
      {_mine, _account_a, my_subject} = owner_subject_fixture()
      {theirs, _account_b, their_subject} = owner_subject_fixture()
      _ = Auth.create_session_token!(theirs, :password, false)
      assert {:ok, [their_session], _} = Auth.list_sessions_for_user(their_subject)

      assert {:error, :not_found} = Auth.revoke_session(their_session.id, my_subject)
      assert {:ok, [_], _} = Auth.list_sessions_for_user(their_subject)
    end

    test "rejects a malformed id without hitting the DB" do
      {_user, _account, subject} = owner_subject_fixture()
      assert {:error, :not_found} = Auth.revoke_session("not-a-uuid", subject)
    end
  end

  describe "revoke_other_sessions!/2" do
    test "keeps the caller's current session" do
      {user, _account, subject} = owner_subject_fixture()
      keep = Auth.create_session_token!(user, :password, false)
      _ = Auth.create_session_token!(user, :password, false)
      _ = Auth.create_session_token!(user, :password, false)

      assert Auth.revoke_other_sessions!(user, keep) == 2
      assert {:ok, [survivor], _} = Auth.list_sessions_for_user(subject)
      assert survivor.token == :crypto.hash(:sha256, keep)
    end

    test "with nil, kills every session including the caller's" do
      {user, _account, subject} = owner_subject_fixture()
      _ = Auth.create_session_token!(user, :password, false)
      _ = Auth.create_session_token!(user, :password, false)

      assert Auth.revoke_other_sessions!(user, nil) == 2
      assert {:ok, [], _} = Auth.list_sessions_for_user(subject)
    end
  end
end
