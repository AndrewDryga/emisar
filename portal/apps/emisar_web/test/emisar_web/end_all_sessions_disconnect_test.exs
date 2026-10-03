defmodule EmisarWeb.EndAllSessionsDisconnectTest do
  @moduledoc """
  An administrator ending a Member's sessions deletes every session of that
  Member and remounts its browsers after commit. The same person's Member of
  another workspace is another Member: its session and socket are untouched.
  The real web disconnect handler delivers the Phoenix broadcast.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Crypto, Fixtures}

  setup do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

    sibling = Fixtures.Accounts.create_account()

    sibling_member =
      Fixtures.Memberships.create_membership(account_id: sibling.id, email: membership.email)

    tokens = for _device <- 1..2, do: Fixtures.Auth.create_session_token!(membership)
    sibling_token = Fixtures.Auth.create_session_token!(sibling_member)

    for token <- [sibling_token | tokens],
        do: EmisarWeb.Endpoint.subscribe(Auth.live_socket_topic(Crypto.hash(token)))

    %{
      owner_subject: Fixtures.Subjects.subject_for(owner),
      membership: membership,
      sibling_member: sibling_member,
      tokens: tokens,
      sibling_token: sibling_token
    }
  end

  test "ending a Member's sessions disconnects each of its browsers and spares the namesake", %{
    owner_subject: owner_subject,
    membership: membership,
    sibling_member: sibling_member,
    tokens: tokens,
    sibling_token: sibling_token
  } do
    assert Accounts.end_all_sessions_for(membership, owner_subject) == :ok

    for token <- tokens do
      topic = Auth.live_socket_topic(Crypto.hash(token))
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
      assert Auth.fetch_session_by_token(token, membership.account_id) == {:error, :not_found}
    end

    sibling_topic = Auth.live_socket_topic(Crypto.hash(sibling_token))
    refute_receive %Phoenix.Socket.Broadcast{topic: ^sibling_topic, event: "disconnect"}, 100

    assert {:ok, %{membership_id: survivor_id}} =
             Auth.fetch_session_by_token(sibling_token, sibling_member.account_id)

    assert survivor_id == sibling_member.id
  end
end
