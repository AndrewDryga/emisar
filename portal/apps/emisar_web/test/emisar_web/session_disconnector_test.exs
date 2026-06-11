defmodule EmisarWeb.SessionDisconnectorTest do
  @moduledoc """
  The web-side half of "kill this user's live sessions": each
  `live_socket_id` topic must receive the `%Phoenix.Socket.Broadcast{}`
  disconnect event LiveView's channel tears down on.
  """
  use EmisarWeb.ConnCase, async: true

  test "broadcasts a disconnect event to every given topic" do
    topics = ["users_sessions:test-#{System.unique_integer([:positive])}", "users_sessions:two"]
    Enum.each(topics, &EmisarWeb.Endpoint.subscribe/1)

    assert :ok = EmisarWeb.SessionDisconnector.disconnect_live_sessions(topics)

    for topic <- topics do
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}
    end
  end

  test "an empty topic list is a no-op" do
    assert :ok = EmisarWeb.SessionDisconnector.disconnect_live_sessions([])
  end
end
