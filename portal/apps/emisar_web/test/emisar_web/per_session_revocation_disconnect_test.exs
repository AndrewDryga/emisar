defmodule EmisarWeb.PerSessionRevocationDisconnectTest do
  @moduledoc """
  Per-session revocation deletes one credential and tears down only the
  LiveView sockets bound to that exact token. The web-side disconnect handler
  is exercised here; data-layer tests cannot observe its Phoenix broadcast.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Fixtures, RequestContext}

  setup do
    {user, account, subject} = Fixtures.Subjects.owner_subject()
    %{user: user, account: account, subject: subject}
  end

  test "a committed revocation disconnects only the selected live session", %{
    user: user,
    subject: subject
  } do
    revoked = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    survivor = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

    assert {:ok, sessions, _metadata} = Auth.list_sessions_for_user(revoked, subject)
    revoked_session = Enum.find(sessions, & &1.current?)

    revoked_topic = Auth.live_socket_topic_for_session(revoked)
    survivor_topic = Auth.live_socket_topic_for_session(survivor)
    EmisarWeb.Endpoint.subscribe(revoked_topic)
    EmisarWeb.Endpoint.subscribe(survivor_topic)

    assert Auth.revoke_session(revoked_session.id, subject) == :ok

    assert_receive %Phoenix.Socket.Broadcast{topic: ^revoked_topic, event: "disconnect"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^survivor_topic, event: "disconnect"}, 100
    assert Auth.fetch_user_and_token_by_session_token(revoked) == {:error, :not_found}
    assert {:ok, ^user, _session} = Auth.fetch_user_and_token_by_session_token(survivor)

    assert Auth.revoke_session(revoked_session.id, subject) == {:error, :not_found}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^revoked_topic, event: "disconnect"}, 100
  end

  test "a foreign session id emits no disconnect and leaves its token live", %{
    subject: subject
  } do
    {other_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
    other_token = Fixtures.Auth.create_session_token!(other_user, :magic_link, nil)
    assert {:ok, [other_session], _metadata} = Auth.list_sessions_for_user(nil, other_subject)

    other_topic = Auth.live_socket_topic_for_session(other_token)
    EmisarWeb.Endpoint.subscribe(other_topic)

    assert Auth.revoke_session(other_session.id, subject) == {:error, :not_found}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}, 100

    assert {:ok, ^other_user, _session} =
             Auth.fetch_user_and_token_by_session_token(other_token)
  end

  test "a rolled-back revocation emits no disconnect and preserves the token", %{
    user: user,
    account: account
  } do
    token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

    subject =
      Fixtures.Subjects.subject_for(user, account,
        context: %RequestContext{request_id: %{invalid: true}}
      )

    assert {:ok, [session], _metadata} = Auth.list_sessions_for_user(nil, subject)
    topic = Auth.live_socket_topic_for_session(token)
    EmisarWeb.Endpoint.subscribe(topic)

    assert {:error, %Ecto.Changeset{}} = Auth.revoke_session(session.id, subject)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
    assert {:ok, ^user, _session} = Auth.fetch_user_and_token_by_session_token(token)
  end
end
