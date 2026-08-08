defmodule EmisarWeb.EndAllSessionsDisconnectTest do
  @moduledoc """
  Admin "end all sessions" must tear the member's open LiveView down, not only
  delete their cookie.

  Each disconnect topic is derived from its `user_tokens` row, so a lookup made
  AFTER the transaction deleted those rows resolves to nothing and disconnects
  no one. That regression is invisible from the `emisar` app alone — the
  disconnect handler lives in `emisar_web` — and it is silent in production:
  the member's cookie dies, so the next HTTP request fails, while their already
  mounted LiveView keeps working until they navigate.

  `Accounts.end_all_sessions_for/2` therefore captures the topics inside the
  transaction and broadcasts the captured list after commit.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures}

  setup do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: owner.id,
      role: "owner"
    )

    owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

    member = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

    token = Fixtures.Auth.create_session_token!(member, :magic_link, false)
    topic = Auth.live_socket_topic_for_session(token)
    EmisarWeb.Endpoint.subscribe(topic)

    %{owner_subject: owner_subject, membership: membership, token: token, topic: topic}
  end

  test "ending a member's sessions disconnects their live socket, not just the cookie", %{
    owner_subject: owner_subject,
    membership: membership,
    token: token,
    topic: topic
  } do
    assert :ok = Accounts.end_all_sessions_for(membership, owner_subject)

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
    assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
  end
end
