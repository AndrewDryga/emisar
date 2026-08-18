defmodule EmisarWeb.SessionDisconnectorTest do
  @moduledoc """
  The web-side half of "kill this user's live sessions": each
  `live_socket_id` topic must receive the `%Phoenix.Socket.Broadcast{}`
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
    user = Fixtures.Users.create_user()
    token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    topic = Auth.live_socket_topic(Crypto.hash(token))
    EmisarWeb.Endpoint.subscribe(topic)

    assert Auth.broadcast_disconnect_for_user(user) == :ok
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}

    assert {:ok, _user, _auth} = Auth.fetch_user_and_token_by_session_token(token)
  end
end
