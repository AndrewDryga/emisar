defmodule Emisar.AuthSessionsTest do
  @moduledoc """
  Behavioural coverage for the user-facing session management surface:
  list, revoke one, revoke-others-keep-current. Not concerned with how
  session tokens are minted (that lives in AuthTest) — only what the
  Profile page calls.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Auth, Config, Crypto, Fixtures, RequestContext}

  defmodule RecordingSessionDisconnector do
    def disconnect_live_sessions(topics) do
      send(self(), {:session_disconnect, topics, Emisar.Repo.in_transaction?()})
      :ok
    end
  end

  describe "list_sessions_for_user/3" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, account: account, subject: subject}
    end

    test "returns the caller's rows newest-first", %{user: user, subject: subject} do
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "expired rows are absent from the page, total, and next cursor", %{
      user: user,
      subject: subject
    } do
      expired = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      live = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      :ok =
        Fixtures.Auth.backdate_session_token!(
          expired,
          DateTime.add(DateTime.utc_now(), -61, :day)
        )

      assert {:ok, [session], metadata} =
               Auth.list_sessions_for_user(Crypto.hash(live), subject, page: [limit: 1])

      assert session.current?
      assert metadata.count == 1
      assert metadata.next_page_cursor == nil
      assert Auth.fetch_user_and_token_by_session_token(expired) == {:error, :not_found}
    end

    test "only returns the subject's own tokens", %{user: mine, subject: my_subject} do
      theirs = Fixtures.Users.create_user()
      Fixtures.Auth.create_session_token!(mine, :magic_link, nil)
      Fixtures.Auth.create_session_token!(theirs, :magic_link, nil)

      assert {:ok, [_], _meta} = Auth.list_sessions_for_user(nil, my_subject)
    end

    test "only includes session-context tokens (not the pending magic-link)", %{
      user: user,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      assert {:ok, _} = Auth.request_magic_link(user, %RequestContext{})

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)
      assert session.current?
    end

    test "marks the presented session current and leaves the others alone", %{
      user: user,
      subject: subject
    } do
      current =
        Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
          "ip_address" => "198.51.100.7"
        })

      Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
        "ip_address" => "203.0.113.9"
      })

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(Crypto.hash(current), subject)
      assert [%{ip_address: "198.51.100.7"}] = Enum.filter(sessions, & &1.current?)
      assert [%{ip_address: "203.0.113.9"}] = Enum.reject(sessions, & &1.current?)
    end

    test "a nil presented token marks every row not-current", %{user: user, subject: subject} do
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(nil, subject)
      refute session.current?
    end

    test "another user's raw token never marks a row current", %{user: user, subject: subject} do
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      theirs =
        Fixtures.Auth.create_session_token!(Fixtures.Users.create_user(), :magic_link, nil)

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(theirs), subject)
      refute session.current?
    end

    test "projects display facts only — never the token, digest, or metadata map", %{
      user: user,
      subject: subject
    } do
      token =
        Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
          "ip_address" => "198.51.100.7",
          "user_agent" => "Mozilla/5.0 Firefox/126.0"
        })

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert %Auth.SessionFacts{
               current?: true,
               ip_address: "198.51.100.7",
               user_agent: "Mozilla/5.0 Firefox/126.0",
               inserted_at: %DateTime{}
             } = session

      # The whole field set — a credential field can never be added back in.
      assert session |> Map.keys() |> Enum.sort() ==
               [:__struct__, :current?, :id, :inserted_at, :ip_address, :user_agent]
    end

    test "a session with no device metadata projects nil display fields", %{
      user: user,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)
      assert session.ip_address == nil
      assert session.user_agent == nil
    end

    test "the same facts come back from a subject scoped to another workspace", %{
      user: user,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      other_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: user.id)
      other_subject = Fixtures.Subjects.subject_for(user, other_account)

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert {:ok, [same_session], _meta} =
               Auth.list_sessions_for_user(Crypto.hash(token), other_subject)

      # Sessions belong to the identity, not to a tenant — same row, same facts.
      assert same_session == session
    end

    test "refuses a non-user subject", %{account: account} do
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Auth.Subject.for_api_key(api_key, account)

      assert Auth.list_sessions_for_user(nil, api_subject) == {:error, :unauthorized}
    end
  end

  describe "revoke_session/2" do
    test ":ok and the row goes away" do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      assert {:ok, [session], _} = Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert Auth.revoke_session(session.id, subject) == :ok
      assert {:ok, [], _} = Auth.list_sessions_for_user(Crypto.hash(token), subject)
    end

    test "disconnects the exact token topic only after commit" do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      assert {:ok, [session], _} = Auth.list_sessions_for_user(Crypto.hash(token), subject)

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      assert Auth.revoke_session(session.id, subject) == :ok

      topic = Auth.live_socket_topic_for_session(token)
      assert_receive {:session_disconnect, [^topic], false}
      refute_receive {:session_disconnect, _topics, _in_transaction?}
    end

    test "refuses to revoke another user's session via id" do
      {_mine, _account_a, my_subject} = Fixtures.Subjects.owner_subject()
      {theirs, _account_b, their_subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Auth.create_session_token!(theirs, :magic_link, nil)
      assert {:ok, [their_session], _} = Auth.list_sessions_for_user(nil, their_subject)

      assert Auth.revoke_session(their_session.id, my_subject) == {:error, :not_found}
      assert {:ok, [_], _} = Auth.list_sessions_for_user(nil, their_subject)
    end

    test "rejects a malformed id without hitting the DB" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      assert Auth.revoke_session("not-a-uuid", subject) == {:error, :not_found}
    end

    test "refuses a non-user subject without touching the session" do
      {user, account, user_subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      assert {:ok, [session], _} = Auth.list_sessions_for_user(Crypto.hash(token), user_subject)
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Auth.Subject.for_api_key(api_key, account)

      assert Auth.revoke_session(session.id, api_subject) == {:error, :unauthorized}
      assert {:ok, ^user, _session} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "revoke_other_sessions!/3" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "keeps the caller's current session", %{user: user, subject: subject} do
      keep = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_other_sessions!(user, Crypto.hash(keep)) == 2
      assert {:ok, [survivor], _} = Auth.list_sessions_for_user(Crypto.hash(keep), subject)
      assert survivor.current?
    end

    test "with nil, kills every session including the caller's", %{user: user, subject: subject} do
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_other_sessions!(user, nil) == 2
      assert {:ok, [], _} = Auth.list_sessions_for_user(nil, subject)
    end
  end
end
