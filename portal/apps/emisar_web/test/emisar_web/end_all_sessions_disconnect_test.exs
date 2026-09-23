defmodule EmisarWeb.EndAllSessionsDisconnectTest do
  @moduledoc """
  Workspace session revocation remounts the affected browser after commit.
  The exact Member's grants disappear, while the bearer and independently proved
  workspaces remain usable. Topics are captured before the grants are deleted;
  the real web disconnect handler delivers the resulting Phoenix broadcast.
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

    sibling = Fixtures.Accounts.create_account()

    sibling_member =
      Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: member.id)

    token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
    topic = Auth.live_socket_topic_for_session(token)
    EmisarWeb.Endpoint.subscribe(topic)

    %{
      owner_subject: owner_subject,
      membership: membership,
      sibling_member: sibling_member,
      token: token,
      topic: topic
    }
  end

  test "ending workspace sessions reconnects the browser without deleting sibling authority", %{
    owner_subject: owner_subject,
    membership: membership,
    sibling_member: sibling_member,
    token: token,
    topic: topic
  } do
    assert Accounts.end_all_sessions_for(membership, owner_subject) == :ok

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
    assert {:ok, session} = Auth.fetch_session_by_token(token)

    assert Accounts.fetch_membership_by_account_id_or_slug(membership.account_id, session) ==
             {:error, :not_found}

    assert {:ok, survivor} =
             Accounts.fetch_membership_by_account_id_or_slug(
               sibling_member.account_id,
               session
             )

    assert survivor.id == sibling_member.id
  end
end
