defmodule Emisar.AuthSessionsTest do
  @moduledoc """
  Behavioural coverage for the user-facing session management surface:
  list, revoke one, revoke-others-keep-current. Not concerned with how
  session tokens are minted (that lives in AuthTest) — only what the
  Profile page calls.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, Config, Crypto, Fixtures, RequestContext}

  defmodule RecordingSessionDisconnector do
    def disconnect_live_sessions(topics) do
      send(self(), {:session_disconnect, topics, Emisar.Repo.in_transaction?()})
      :ok
    end
  end

  describe "personal_session?/1" do
    test "only a live boundary token's independent, unexpired email proof allows the form" do
      {user, _account, subject, personal} = personal_owner_subject()
      assert {:ok, session} = Auth.fetch_current_session(subject)
      assert Auth.personal_session?(session)

      sso = Fixtures.Auth.create_session_token!(user, :sso, DateTime.utc_now())
      assert {:ok, sso_session} = Auth.fetch_session_by_token(sso)
      refute Auth.personal_session?(sso_session)

      Fixtures.Auth.expire_session_independent_proofs!(personal)
      assert {:ok, expired_proof} = Auth.fetch_current_session(subject)
      refute Auth.personal_session?(expired_proof)
      refute Auth.personal_session?(nil)
    end
  end

  describe "list_sessions_for_user/3" do
    setup context do
      {user, account, subject, token} =
        personal_owner_subject(Map.get(context, :session_metadata, %{}))

      %{user: user, account: account, subject: subject, token: token}
    end

    test "returns the caller's rows newest-first", %{user: user, subject: subject} do
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "expired rows are absent from the page, total, and next cursor", %{
      user: user,
      subject: subject,
      token: live
    } do
      expired = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

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
      assert Auth.fetch_session_by_token(expired) == {:error, :not_found}
    end

    test "only returns the subject's own tokens", %{subject: my_subject} do
      theirs = Fixtures.Users.create_user()
      Fixtures.Auth.create_session_token!(theirs, :magic_link, nil)

      assert {:ok, [_], _meta} = Auth.list_sessions_for_user(nil, my_subject)
    end

    test "only includes session-context tokens (not the pending magic-link)", %{
      user: user,
      subject: subject,
      token: token
    } do
      assert {:ok, _} = Auth.request_magic_link(user, %RequestContext{})

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)
      assert session.current?
    end

    @tag session_metadata: %{ip_address: "198.51.100.7"}
    test "marks the presented session current and leaves the others alone", %{
      user: user,
      subject: subject,
      token: current
    } do
      Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
        ip_address: "203.0.113.9"
      })

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(Crypto.hash(current), subject)
      assert [%{ip_address: "198.51.100.7"}] = Enum.filter(sessions, & &1.current?)
      assert [%{ip_address: "203.0.113.9"}] = Enum.reject(sessions, & &1.current?)
    end

    test "a nil presented token marks every row not-current", %{subject: subject} do
      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(nil, subject)
      refute session.current?
    end

    test "another user's raw token never marks a row current", %{subject: subject} do
      theirs =
        Fixtures.Auth.create_session_token!(Fixtures.Users.create_user(), :magic_link, nil)

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(theirs), subject)
      refute session.current?
    end

    @tag session_metadata: %{
           ip_address: "198.51.100.7",
           user_agent: "Mozilla/5.0 Firefox/126.0"
         }
    test "projects display facts only — never the token, digest, or metadata map", %{
      subject: subject,
      token: token
    } do
      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert %Auth.SessionFacts{
               current?: true,
               ip_address: "198.51.100.7",
               user_agent: "Mozilla/5.0 Firefox/126.0",
               auth_method: :magic_link,
               inserted_at: %DateTime{}
             } = session

      # The whole field set — a credential field can never be added back in.
      assert session |> Map.keys() |> Enum.sort() ==
               [:__struct__, :auth_method, :current?, :id, :inserted_at, :ip_address, :user_agent]
    end

    test "projects the recorded SSO method without identity or assurance fields", %{
      user: user,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(user, :sso, DateTime.utc_now())

      assert {:ok, [session, personal], _} =
               Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert personal.id == subject.session_token_id
      assert session.current?
      assert session.auth_method == :sso
      refute Map.has_key?(session, :user_identity_id)
      refute Map.has_key?(session, :mfa_verified_at)
    end

    test "a session with no device metadata projects nil display fields", %{
      subject: subject,
      token: token
    } do
      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)
      assert session.ip_address == nil
      assert session.user_agent == nil
    end

    test "the same facts come back from a subject scoped to another workspace", %{
      user: user,
      subject: subject,
      token: token
    } do
      other_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: user.id)
      other_subject = Fixtures.Subjects.subject_for(user, other_account, auth_method: :magic_link)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert {:ok, same_sessions, _meta} =
               Auth.list_sessions_for_user(Crypto.hash(token), other_subject)

      # Personal session management sees both browsers, regardless of workspace.
      assert same_sessions == sessions

      assert Enum.sort(Enum.map(sessions, & &1.id)) ==
               Enum.sort([subject.session_token_id, other_subject.session_token_id])
    end

    test "refuses a non-user subject", %{account: account} do
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Auth.Subject.for_api_key(api_key, account)

      assert Auth.list_sessions_for_user(nil, api_subject) == {:error, :unauthorized}
    end
  end

  describe "revoke_session/2" do
    test ":ok and the row goes away" do
      {user, _account, subject, _current} = personal_owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, [session, caller], _} =
               Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert caller.id == subject.session_token_id

      assert Auth.revoke_session(session.id, subject) == :ok
      assert {:ok, [^caller], _} = Auth.list_sessions_for_user(Crypto.hash(token), subject)
    end

    test "disconnects the exact token topic only after commit" do
      {user, _account, subject, _current} = personal_owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, [session, caller], _} =
               Auth.list_sessions_for_user(Crypto.hash(token), subject)

      assert caller.id == subject.session_token_id

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
      {_mine, _account_a, my_subject, _mine_token} = personal_owner_subject()
      {_theirs, _account_b, their_subject, _their_token} = personal_owner_subject()
      assert {:ok, [their_session], _} = Auth.list_sessions_for_user(nil, their_subject)

      assert Auth.revoke_session(their_session.id, my_subject) == {:error, :not_found}
      assert {:ok, [_], _} = Auth.list_sessions_for_user(nil, their_subject)
    end

    test "rejects a malformed id without hitting the DB" do
      {_user, _account, subject, _token} = personal_owner_subject()
      assert Auth.revoke_session("not-a-uuid", subject) == {:error, :not_found}
    end

    test "refuses a non-user subject without touching the session" do
      {user, account, user_subject, token} = personal_owner_subject()
      assert {:ok, [session], _} = Auth.list_sessions_for_user(Crypto.hash(token), user_subject)
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Auth.Subject.for_api_key(api_key, account)

      assert Auth.revoke_session(session.id, api_subject) == {:error, :unauthorized}
      assert {:ok, %{user: ^user}} = Auth.fetch_session_by_token(token)
    end
  end

  describe "revoke_and_disconnect_other_sessions/2" do
    setup do
      {user, _account, subject, token} = personal_owner_subject()
      %{user: user, subject: subject, token: token}
    end

    test "with only the current session, revokes nothing", %{subject: subject, token: keep} do
      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) == {:ok, 0}
      assert {:ok, _} = Auth.fetch_session_by_token(keep)
    end

    test "keeps the caller's current session", %{user: user, subject: subject, token: keep} do
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) == {:ok, 2}
      assert {:ok, [survivor], _} = Auth.list_sessions_for_user(Crypto.hash(keep), subject)
      assert survivor.current?
    end

    test "a revoked caller cannot end the remaining browser", %{
      user: user,
      subject: subject,
      token: keep
    } do
      other = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.delete_session_token!(keep)

      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) ==
               {:error, :unauthorized}

      assert {:ok, _} = Auth.fetch_session_by_token(other)
    end

    test "expired personal proof cannot end another browser", %{
      user: user,
      subject: subject,
      token: keep
    } do
      other = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.expire_session_independent_proofs!(keep)

      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) ==
               {:error, :unauthorized}

      assert {:ok, _} = Auth.fetch_session_by_token(other)
    end

    test "revokes owned SSO sessions too, leaves another user alone, and disconnects after commit",
         %{
           user: user,
           subject: subject,
           token: keep
         } do
      other = Fixtures.Auth.create_session_token!(user, :sso, nil)

      foreign =
        Fixtures.Auth.create_session_token!(Fixtures.Users.create_user(), :magic_link, nil)

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) == {:ok, 1}
      topic = Auth.live_socket_topic_for_session(other)
      assert_receive {:session_disconnect, [^topic], false}
      assert {:ok, _} = Auth.fetch_session_by_token(keep)
      assert {:ok, _} = Auth.fetch_session_by_token(foreign)
    end

    test "audit rejection preserves sessions and emits no disconnect", %{
      user: user,
      subject: subject,
      token: keep
    } do
      other = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      subject = %{subject | context: %RequestContext{request_id: %{invalid: true}}}

      assert {:error, %Ecto.Changeset{}} =
               Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject)

      refute_received {:session_disconnect, _, _}
      assert {:ok, _} = Auth.fetch_session_by_token(keep)
      assert {:ok, _} = Auth.fetch_session_by_token(other)
    end
  end

  defp personal_owner_subject(metadata \\ %{}) do
    user = Fixtures.Users.create_user()
    {:ok, account} = Accounts.create_account_with_owner(Fixtures.Accounts.account_attrs(), user)
    raw = Fixtures.Auth.create_session_token!(user, :magic_link, nil, metadata)
    {:ok, session} = Auth.fetch_session_by_token(raw)
    subject = Fixtures.Subjects.subject_for(user, account, session: session)
    {user, account, subject, raw}
  end
end
