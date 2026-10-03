defmodule EmisarWeb.SessionDisconnectorTest do
  @moduledoc """
  The web-side half of "end these sessions' sockets": each session's
  topic must receive the `%Phoenix.Socket.Broadcast{}`
  disconnect event LiveView's channel tears down on.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Crypto, Fixtures}

  test "broadcasts a disconnect event to every given topic" do
    topics = ["users_sessions:test-#{System.unique_integer([:positive])}", "users_sessions:two"]
    Enum.each(topics, &EmisarWeb.Endpoint.subscribe/1)

    assert EmisarWeb.SessionDisconnector.disconnect_live_sessions(topics) == :ok

    for topic <- topics do
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}
    end
  end

  test "an empty topic list is a no-op" do
    assert EmisarWeb.SessionDisconnector.disconnect_live_sessions([]) == :ok
  end

  test "Auth calls the handler while the web application is running" do
    member = Fixtures.Memberships.create_membership()
    token = Fixtures.Auth.create_session_token!(member)
    topic = Auth.live_socket_topic(Crypto.hash(token))
    EmisarWeb.Endpoint.subscribe(topic)

    assert Auth.disconnect_live_socket_topics([topic]) == :ok
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}

    # Disconnecting sockets ends no session: only revocation deletes the row.
    assert {:ok, _auth} = Auth.fetch_session_by_token(token, member.account_id)
  end
end
