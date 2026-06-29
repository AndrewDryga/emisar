defmodule Emisar.AuthSessionsTest do
  @moduledoc """
  Behavioural coverage for the user-facing session management surface:
  list, revoke one, revoke-others-keep-current. Not concerned with how
  session tokens are minted (that lives in AuthTest) — only what the
  Profile page calls.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Auth
  alias Emisar.Fixtures

  describe "list_sessions_for_user/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "returns the caller's rows newest-first", %{user: user, subject: subject} do
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "only returns the subject's own tokens", %{user: mine, subject: my_subject} do
      theirs = Fixtures.Users.create_user()
      _ = Auth.create_session_token!(mine, :magic_link, false)
      _ = Auth.create_session_token!(theirs, :magic_link, false)

      assert {:ok, [_], _meta} = Auth.list_sessions_for_user(my_subject)
    end

    test "only includes session-context tokens (not the pending magic-link)", %{
      user: user,
      subject: subject
    } do
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.issue_magic_link(user)

      assert {:ok, [token], _meta} = Auth.list_sessions_for_user(subject)
      assert token.context == "session"
    end
  end

  describe "revoke_session/2" do
    test ":ok and the row goes away" do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      _ = Auth.create_session_token!(user, :magic_link, false)
      assert {:ok, [session], _} = Auth.list_sessions_for_user(subject)

      assert :ok = Auth.revoke_session(session.id, subject)
      assert {:ok, [], _} = Auth.list_sessions_for_user(subject)
    end

    test "refuses to revoke another user's session via id" do
      {_mine, _account_a, my_subject} = Fixtures.Subjects.owner_subject()
      {theirs, _account_b, their_subject} = Fixtures.Subjects.owner_subject()
      _ = Auth.create_session_token!(theirs, :magic_link, false)
      assert {:ok, [their_session], _} = Auth.list_sessions_for_user(their_subject)

      assert {:error, :not_found} = Auth.revoke_session(their_session.id, my_subject)
      assert {:ok, [_], _} = Auth.list_sessions_for_user(their_subject)
    end

    test "rejects a malformed id without hitting the DB" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Auth.revoke_session("not-a-uuid", subject)
    end
  end

  describe "revoke_other_sessions!/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "keeps the caller's current session", %{user: user, subject: subject} do
      keep = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_other_sessions!(user, keep) == 2
      assert {:ok, [survivor], _} = Auth.list_sessions_for_user(subject)
      assert survivor.token == :crypto.hash(:sha256, keep)
    end

    test "with nil, kills every session including the caller's", %{user: user, subject: subject} do
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_other_sessions!(user, nil) == 2
      assert {:ok, [], _} = Auth.list_sessions_for_user(subject)
    end
  end
end
